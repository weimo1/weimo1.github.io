import os
config_path = os.path.join(r'F:\weimo-blog', '_config.yml')
with open(config_path, 'r', encoding='utf-8') as f:
    content = f.read()
content = content.replace('title: Hexo', "title: weimo's blog")
content = content.replace("subtitle: ''", "subtitle: '技术笔记与思考'")
content = content.replace("description: ''", "description: '个人技术博客'")
content = content.replace('author: John Doe', 'author: weimo')
content = content.replace('language: en', 'language: zh-CN')
content = content.replace("timezone: ''", "timezone: 'Asia/Shanghai'")
content = content.replace('url: http://example.com', 'url: https://weimo.github.io')
content = content.replace('permalink: :year/:month/:day/:title/', 'permalink: posts/:title/')
content = content.replace('theme: landscape', 'theme: butterfly')
content = content.replace("deploy:\n  type: ''", "deploy:\n  type: git\n  repo: https://github.com/weimo/weimo.github.io.git\n  branch: main")
with open(config_path, 'w', encoding='utf-8') as f:
    f.write(content)
print('config updated')
